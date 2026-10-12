/*==============================================================================
  06_analysis.sql  --  AD-HOC ANALYSIS (all subject areas in one file)
  Source: bi.* views on Manufacturing_DW. Read-only exploration that drives the
  report design. Results summary: sql\FINDINGS.md
  Run: sqlcmd -S localhost -d Manufacturing_DW -E -C -i sql\06_analysis.sql
  Sections: A) Sales  B) Inventory  C) Procurement  D) Logistics  E) Executive
==============================================================================*/

/*==============================================================================
  SECTION A -- SALES / CUSTOMER FULFILLMENT  (bi.FactSalesOrder)
==============================================================================*/

/* A1. Headline sales KPIs */
SELECT
    COUNT(*)                                            AS OrderLines,
    COUNT(DISTINCT [Sales Order ID])                    AS Orders,
    SUM([Order Quantity])                               AS OrderQty,
    SUM([Fulfilled Quantity])                           AS FulfilledQty,
    SUM([Backorder Quantity])                           AS BackorderQty,
    SUM([Gross Line Amount])                            AS GrossSales,
    SUM([Discount Amount])                              AS Discount,
    SUM([Net Line Amount])                              AS NetSales,
    CAST(100.0*SUM([Fulfilled Quantity])/NULLIF(SUM([Order Quantity]),0)  AS DECIMAL(5,1)) AS FillRatePct,
    CAST(100.0*SUM([Discount Amount])  /NULLIF(SUM([Gross Line Amount]),0) AS DECIMAL(5,1)) AS DiscountPct
FROM bi.FactSalesOrder;

/* A2. Monthly trend (growth / seasonality) */
SELECT d.[Year], d.[Month Number] AS Mth, d.[Year-Month] AS YearMonth,
       SUM(f.[Net Line Amount]) AS NetSales,
       COUNT(DISTINCT f.[Sales Order ID]) AS Orders,
       CAST(100.0*SUM(f.[Fulfilled Quantity])/NULLIF(SUM(f.[Order Quantity]),0) AS DECIMAL(5,1)) AS FillRatePct
FROM bi.FactSalesOrder f JOIN bi.DimDate d ON d.DateKey = f.OrderDateKey
GROUP BY d.[Year], d.[Month Number], d.[Year-Month]
ORDER BY d.[Year], d.[Month Number];

/* A3. By customer type & segment */
SELECT c.[Customer Type], c.[Customer Segment],
       SUM(f.[Net Line Amount]) AS NetSales,
       CAST(100.0*SUM(f.[Fulfilled Quantity])/NULLIF(SUM(f.[Order Quantity]),0) AS DECIMAL(5,1)) AS FillRatePct,
       SUM(f.[Backorder Quantity]) AS BackorderQty
FROM bi.FactSalesOrder f JOIN bi.DimCustomer c ON c.CustomerKey = f.CustomerKey
GROUP BY c.[Customer Type], c.[Customer Segment] ORDER BY NetSales DESC;

/* A4. By region & sales channel */
SELECT c.[Region], f.[Sales Channel],
       SUM(f.[Net Line Amount]) AS NetSales, COUNT(DISTINCT f.[Sales Order ID]) AS Orders
FROM bi.FactSalesOrder f JOIN bi.DimCustomer c ON c.CustomerKey = f.CustomerKey
GROUP BY c.[Region], f.[Sales Channel] ORDER BY NetSales DESC;

/* A5. Top 15 products by net sales */
SELECT TOP 15 p.[Product ID], p.[Product Name], p.[Category], p.[ABC Class],
       SUM(f.[Net Line Amount]) AS NetSales, SUM(f.[Order Quantity]) AS OrderQty
FROM bi.FactSalesOrder f JOIN bi.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY p.[Product ID], p.[Product Name], p.[Category], p.[ABC Class]
ORDER BY NetSales DESC;

/* A6. Net sales by ABC class (Pareto) */
SELECT p.[ABC Class], COUNT(DISTINCT p.[Product ID]) AS Products,
       SUM(f.[Net Line Amount]) AS NetSales,
       CAST(100.0*SUM(f.[Net Line Amount])/SUM(SUM(f.[Net Line Amount])) OVER() AS DECIMAL(5,1)) AS PctOfSales
FROM bi.FactSalesOrder f JOIN bi.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY p.[ABC Class] ORDER BY p.[ABC Class];

/* A7. Order / line status mix */
SELECT f.[Order Status], COUNT(DISTINCT f.[Sales Order ID]) AS Orders FROM bi.FactSalesOrder f GROUP BY f.[Order Status] ORDER BY Orders DESC;
SELECT f.[Line Status], COUNT(*) AS Lines FROM bi.FactSalesOrder f GROUP BY f.[Line Status] ORDER BY Lines DESC;

/* A8. Backorder rate by category */
SELECT p.[Category],
       SUM(f.[Backorder Quantity]) AS BackorderQty,
       CAST(100.0*SUM(f.[Backorder Quantity])/NULLIF(SUM(f.[Order Quantity]),0) AS DECIMAL(5,1)) AS BackorderPct
FROM bi.FactSalesOrder f JOIN bi.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY p.[Category] ORDER BY BackorderPct DESC;
GO

/*==============================================================================
  SECTION B -- INVENTORY  (bi.FactInventorySnapshot, latest snapshot)
==============================================================================*/
DECLARE @Snap INT = (SELECT MAX(SnapshotDateKey) FROM bi.FactInventorySnapshot);

/* B1. Headline inventory KPIs */
SELECT COUNT(*) AS StockedBins, SUM([On Hand Quantity]) AS OnHand, SUM([Available Quantity]) AS Available,
       SUM([Reserved Quantity]) AS Reserved, SUM([In Transit Quantity]) AS InTransit, SUM([Inventory Value]) AS InventoryValue
FROM bi.FactInventorySnapshot WHERE SnapshotDateKey = @Snap;

/* B2. Stock-status distribution */
SELECT [Stock Status], COUNT(*) AS Bins, SUM([Inventory Value]) AS InventoryValue,
       CAST(100.0*COUNT(*)/SUM(COUNT(*)) OVER() AS DECIMAL(5,1)) AS PctBins
FROM bi.FactInventorySnapshot WHERE SnapshotDateKey = @Snap GROUP BY [Stock Status] ORDER BY Bins DESC;

/* B3. Movement-class distribution */
SELECT [Movement Class], COUNT(*) AS Bins, SUM([Inventory Value]) AS InventoryValue
FROM bi.FactInventorySnapshot WHERE SnapshotDateKey = @Snap GROUP BY [Movement Class] ORDER BY InventoryValue DESC;

/* B4. Inventory value & risk by warehouse */
SELECT w.[Warehouse ID], w.[Warehouse Name], w.[Region],
       SUM(f.[Inventory Value]) AS InventoryValue,
       SUM(CASE WHEN f.[Stock Status]='Stockout' THEN 1 ELSE 0 END) AS Stockouts,
       SUM(CASE WHEN f.[Stock Status] IN ('Below Safety Stock','Below Reorder') THEN 1 ELSE 0 END) AS LowStockBins
FROM bi.FactInventorySnapshot f JOIN bi.DimWarehouse w ON w.WarehouseKey = f.WarehouseKey
WHERE f.SnapshotDateKey = @Snap GROUP BY w.[Warehouse ID], w.[Warehouse Name], w.[Region] ORDER BY InventoryValue DESC;

/* B5. Inventory value by category */
SELECT p.[Category], SUM(f.[Inventory Value]) AS InventoryValue, SUM(f.[On Hand Quantity]) AS OnHand
FROM bi.FactInventorySnapshot f JOIN bi.DimProduct p ON p.ProductKey = f.ProductKey
WHERE f.SnapshotDateKey = @Snap GROUP BY p.[Category] ORDER BY InventoryValue DESC;

/* B6. Products needing action (stockout / below reorder) */
SELECT TOP 20 p.[Product ID], p.[Product Name], w.[Warehouse ID],
       f.[On Hand Quantity], p.[Reorder Level], p.[Safety Stock Quantity], f.[Stock Status], f.[Inventory Value]
FROM bi.FactInventorySnapshot f
JOIN bi.DimProduct p ON p.ProductKey = f.ProductKey
JOIN bi.DimWarehouse w ON w.WarehouseKey = f.WarehouseKey
WHERE f.SnapshotDateKey = @Snap AND f.[Stock Status] IN ('Stockout','Below Safety Stock','Below Reorder')
ORDER BY f.[Inventory Value] DESC;

/* B7. Excess stock */
SELECT p.[Category], COUNT(*) AS ExcessBins, SUM(f.[Inventory Value]) AS ExcessValue
FROM bi.FactInventorySnapshot f JOIN bi.DimProduct p ON p.ProductKey = f.ProductKey
WHERE f.SnapshotDateKey = @Snap AND f.[Stock Status]='Excess' GROUP BY p.[Category] ORDER BY ExcessValue DESC;
GO

/*==============================================================================
  SECTION C -- PROCUREMENT / SUPPLIERS  (bi.FactPurchaseOrder)
  On-time from [Delivery Status] ('On Time' / 'Late' / 'Pending').
==============================================================================*/

/* C1. Headline procurement KPIs */
SELECT
    COUNT(*) AS POLines, COUNT(DISTINCT [Purchase Order ID]) AS POs,
    SUM([Line Amount]) AS POValue, SUM([Open Quantity]*[Unit Cost]) AS OpenPOValue,
    SUM([Ordered Quantity]) AS OrderedQty, SUM([Received Quantity]) AS ReceivedQty, SUM([Rejected Quantity]) AS RejectedQty,
    CAST(100.0*SUM([Rejected Quantity])/NULLIF(SUM([Accepted Quantity])+SUM([Rejected Quantity]),0) AS DECIMAL(5,2)) AS RejectionPct,
    CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS SupplierOnTimePct,
    AVG(CAST([Supplier Delay Days] AS DECIMAL(6,2))) AS AvgDelayDays
FROM bi.FactPurchaseOrder;

/* C2. On-time % & rejection by supplier RISK */
SELECT s.[Supplier Risk], COUNT(DISTINCT s.[Supplier ID]) AS Suppliers,
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       CAST(100.0*SUM(f.[Rejected Quantity])/NULLIF(SUM(f.[Accepted Quantity])+SUM(f.[Rejected Quantity]),0) AS DECIMAL(5,2)) AS RejectionPct,
       AVG(CAST(f.[Supplier Delay Days] AS DECIMAL(6,2))) AS AvgDelayDays
FROM bi.FactPurchaseOrder f JOIN bi.DimSupplier s ON s.SupplierKey = f.SupplierKey
GROUP BY s.[Supplier Risk] ORDER BY OnTimePct DESC;

/* C3. Worst 15 suppliers by on-time % (>=20 lines) */
SELECT TOP 15 s.[Supplier ID], s.[Supplier Name], s.[Supplier Tier], s.[Supplier Risk], COUNT(*) AS POLines,
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       SUM(f.[Line Amount]) AS POValue
FROM bi.FactPurchaseOrder f JOIN bi.DimSupplier s ON s.SupplierKey = f.SupplierKey
GROUP BY s.[Supplier ID], s.[Supplier Name], s.[Supplier Tier], s.[Supplier Risk]
HAVING COUNT(*) >= 20 ORDER BY OnTimePct ASC;

/* C4. PO value & open-PO by buyer group */
SELECT f.[Buyer Group], SUM(f.[Line Amount]) AS POValue, SUM(f.[Open Quantity]*f.[Unit Cost]) AS OpenPOValue,
       SUM(CASE WHEN f.[PO Status] IN ('Open','Partially Received') THEN 1 ELSE 0 END) AS OpenLines
FROM bi.FactPurchaseOrder f GROUP BY f.[Buyer Group] ORDER BY POValue DESC;

/* C5. Monthly PO value & avg unit cost (cost inflation story) */
SELECT d.[Year], d.[Month Number] AS Mth, SUM(f.[Line Amount]) AS POValue, AVG(f.[Unit Cost]) AS AvgUnitCost
FROM bi.FactPurchaseOrder f JOIN bi.DimDate d ON d.DateKey = f.OrderDateKey
GROUP BY d.[Year], d.[Month Number] ORDER BY d.[Year], d.[Month Number];

/* C6. PO / line status mix */
SELECT f.[PO Status], COUNT(DISTINCT f.[Purchase Order ID]) AS POs FROM bi.FactPurchaseOrder f GROUP BY f.[PO Status] ORDER BY POs DESC;
SELECT f.[Line Status], COUNT(*) AS Lines FROM bi.FactPurchaseOrder f GROUP BY f.[Line Status] ORDER BY Lines DESC;
GO

/*==============================================================================
  SECTION D -- LOGISTICS / SHIPMENTS  (bi.FactShipment)
==============================================================================*/

/* D1. Headline logistics KPIs */
SELECT COUNT(*) AS ShipmentLines, COUNT(DISTINCT [Shipment ID]) AS Shipments,
       SUM([Shipped Quantity]) AS ShippedQty, SUM([Shipping Cost]) AS ShippingCost,
       CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       SUM(CASE WHEN [Delivery Status]='Late' THEN 1 ELSE 0 END) AS LateLines,
       AVG(CAST([Delivery Delay Days] AS DECIMAL(6,2))) AS AvgDelayDays,
       CAST(100.0*SUM(CAST([Return Flag] AS INT))/NULLIF(COUNT(*),0) AS DECIMAL(5,2)) AS ReturnPct
FROM bi.FactShipment;

/* D2. On-time % & cost by carrier */
SELECT c.[Carrier Name], c.[Carrier Type], c.[Carrier Rating], COUNT(*) AS Lines,
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       SUM(f.[Shipping Cost]) AS ShippingCost
FROM bi.FactShipment f JOIN bi.DimCarrier c ON c.CarrierKey = f.CarrierKey
GROUP BY c.[Carrier Name], c.[Carrier Type], c.[Carrier Rating] ORDER BY OnTimePct DESC;

/* D3. On-time & cost by mode & service level */
SELECT f.[Shipment Mode], f.[Service Level], COUNT(*) AS Lines,
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       AVG(f.[Shipping Cost]) AS AvgShippingCost
FROM bi.FactShipment f GROUP BY f.[Shipment Mode], f.[Service Level] ORDER BY Lines DESC;

/* D4. On-time by destination region */
SELECT f.[Destination Region], COUNT(*) AS Lines,
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       SUM(f.[Shipping Cost]) AS ShippingCost
FROM bi.FactShipment f GROUP BY f.[Destination Region] ORDER BY ShippingCost DESC;

/* D5. Monthly on-time & shipping-cost trend */
SELECT d.[Year], d.[Month Number] AS Mth,
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct,
       SUM(f.[Shipping Cost]) AS ShippingCost
FROM bi.FactShipment f JOIN bi.DimDate d ON d.DateKey = f.ShipmentDateKey
GROUP BY d.[Year], d.[Month Number] ORDER BY d.[Year], d.[Month Number];

/* D6. Returns by reason */
SELECT f.[Return Reason], COUNT(*) AS Lines FROM bi.FactShipment f WHERE f.[Return Flag] = 1 GROUP BY f.[Return Reason] ORDER BY Lines DESC;

/* D7. Shipment status mix (pipeline) */
SELECT f.[Shipment Status], COUNT(DISTINCT f.[Shipment ID]) AS Shipments FROM bi.FactShipment f GROUP BY f.[Shipment Status] ORDER BY Shipments DESC;
GO

/*==============================================================================
  SECTION E -- EXECUTIVE roll-up
==============================================================================*/

/* E1. Executive scorecard (single row) */
SELECT
    (SELECT SUM([Net Line Amount]) FROM bi.FactSalesOrder) AS NetSales,
    (SELECT CAST(100.0*SUM([Fulfilled Quantity])/NULLIF(SUM([Order Quantity]),0) AS DECIMAL(5,1)) FROM bi.FactSalesOrder) AS FillRatePct,
    (SELECT SUM([Backorder Quantity]) FROM bi.FactSalesOrder) AS BackorderQty,
    (SELECT SUM([Line Amount]) FROM bi.FactPurchaseOrder) AS POValue,
    (SELECT SUM([Open Quantity]*[Unit Cost]) FROM bi.FactPurchaseOrder) AS OpenPOValue,
    (SELECT CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) FROM bi.FactPurchaseOrder) AS SupplierOnTimePct,
    (SELECT CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) FROM bi.FactShipment) AS DeliveryOnTimePct,
    (SELECT CAST(100.0*SUM(CAST([Return Flag] AS INT))/NULLIF(COUNT(*),0) AS DECIMAL(5,2)) FROM bi.FactShipment) AS ReturnPct,
    (SELECT SUM([Shipping Cost]) FROM bi.FactShipment) AS ShippingCost,
    (SELECT SUM([Inventory Value]) FROM bi.FactInventorySnapshot WHERE SnapshotDateKey=(SELECT MAX(SnapshotDateKey) FROM bi.FactInventorySnapshot)) AS InventoryValue;

/* E2. Net sales by year + YoY growth % */
WITH yr AS (
    SELECT d.[Year] AS Yr, SUM(f.[Net Line Amount]) AS NetSales
    FROM bi.FactSalesOrder f JOIN bi.DimDate d ON d.DateKey=f.OrderDateKey GROUP BY d.[Year]
)
SELECT Yr, NetSales, LAG(NetSales) OVER (ORDER BY Yr) AS PrevYear,
       CAST(100.0*(NetSales - LAG(NetSales) OVER (ORDER BY Yr))/NULLIF(LAG(NetSales) OVER (ORDER BY Yr),0) AS DECIMAL(6,1)) AS YoYGrowthPct
FROM yr ORDER BY Yr;
GO
