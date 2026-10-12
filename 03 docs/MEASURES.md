# Measure Catalog — Manufacturing Supply Chain Model

Every measure lives in the single `_Measures` table, grouped in one level of display folders. Fact and dimension tables hold data only.
Measures sit above the columns, and derived measures are built on top of base measures. Generated from the TMDL: model descriptions are the source of truth.

**222 measures** (9 hidden helpers) in 40 sub-folders.

## Conditional Formatting

| Measure | Format | Meaning |
|---|---|---|
| Color Bad *(hidden)* | `General` | Hex colour for a bad / off-target status. |
| Color Good *(hidden)* | `General` | Hex colour for a good / on-target status. Change here to re-theme every status colour in the model. |
| Color Neutral *(hidden)* | `General` | Hex colour when there is nothing to compare against. |
| Color Warning *(hidden)* | `General` | Hex colour for a watch / near-target status. |
| Status Tolerance *(hidden)* | `0.0%` | Share (or percentage points) a KPI may miss its comparison by and still be a Watch rather than Bad. |

## Drillthrough

| Measure | Format | Meaning |
|---|---|---|
| # Warehouses Stocking | `#,##0` | Warehouses holding stock (on hand above zero) at the latest snapshot. |
| Delivery On-Time vs All Products (pp) | `+0.0%;-0.0%;0.0%` | Delivery on-time of the product(s) minus that of all products, in percentage points. |
| Fill Rate vs All Products (pp) | `+0.0%;-0.0%;0.0%` | Fill rate of the product(s) minus the fill rate of all products, in percentage points. |
| Product Share of Net Sales (%) | `0.00%` | Share of all Net Sales that the product(s) in context represent. Ignores the product filter, respects the others. |

## Dynamic - KPI Selection

| Measure | Format | Meaning |
|---|---|---|
| KPI Direction *(hidden)* | `0` | Helper: 1 when higher is better, -1 when lower is better, 0 when neither (Inventory Value). |
| KPI Is Percent *(hidden)* | `0` | Helper: 1 when the selected KPI is a percentage. |
| KPI Value (context) *(hidden)* | `General` | Helper: value of the selected KPI in the current filter context, via SWITCH. |
| Selected KPI | `General` | KPI chosen in the KPI Selector slicer (default Net Sales). Drives the dynamic KPI card. |
| Selected KPI Compare Value | `General` | Selected KPI over the comparison basis: last year, previous period, or its target. |
| Selected KPI Status | `0` | 1 = better than or equal to the comparison, 0 = worse by less than the tolerance, -1 = worse. Blank when direction is neutral or nothing to compare. |
| Selected KPI Status Color | `General` | Hex colour for the selected KPI's status, for conditional formatting. |
| Selected KPI Subtitle | `General` | Period and comparison basis under the dynamic KPI card. |
| Selected KPI Target | `General` | Target or limit of the selected KPI from the what-if slicers; blank where none is defined (Net Sales, Inventory Value, Stockout Bins). |
| Selected KPI Value | `General` | Selected KPI over the selected period (overrides the date slicers). |
| Selected KPI Value Text | `General` | Selected KPI formatted for a card: $1.2M, 91.3%, 46. |
| Selected KPI Variance | `+0.0%;-0.0%;0.0%` | Percentage-point difference for percent KPIs, relative change for the others (0.05 = +5%). Blank when there is nothing to compare. |
| Selected KPI Variance Text | `General` | Variance as text with its basis, e.g. +1.2 pp vs same period last year. |

## Dynamic - Period Selection

| Measure | Format | Meaning |
|---|---|---|
| Compare End Date | `dd-MMM-yyyy` | End of the comparison window. Blank for Target. |
| Compare Label | `General` | Readable comparison basis for KPI subtitles. |
| Compare Start Date | `dd-MMM-yyyy` | Start of the comparison window: same dates last year, or the equally long period just before. Blank for Target. |
| Is In Selected Period | `0` | 1 when the date in context falls inside the selected period, else 0. Use as a visual-level filter (= 1) on charts with a date axis. |
| Last Sales Date | `dd-MMM-yyyy` | The most recent order date in the data, ignoring filters. Relative periods are anchored here because the data ends before today. |
| Period End Date | `dd-MMM-yyyy` | End of the selected period: always the last date with sales. |
| Period Label | `General` | Readable selected period, e.g. Last 12 Months (26-Aug-2025 to 25-Aug-2026). |
| Period Start Date | `dd-MMM-yyyy` | Start of the selected period, counted back from the last sales date. All Time starts at the first date in the calendar. |
| Selected Comparison | `General` | Comparison chosen in the Compare To slicer (default Last Year). |
| Selected Period | `General` | Period chosen in the Period Selector slicer (default Last 12 Months). |

## Dynamic - Time Basis

| Measure | Format | Meaning |
|---|---|---|
| Net Sales (time basis) | `$#,##0.00` | Net Sales on the chosen time basis (SWITCH over mtd, qtd, ytd, ltm, same period last year). Use on a date-axis chart. |
| Selected Time Basis | `General` | Time basis chosen in the Time Basis slicer (default As Filtered). |

## Dynamic - Titles

| Measure | Format | Meaning |
|---|---|---|
| Customer Scope Text | `General` | Customer-type selection in words. |
| Date Range Text | `General` | Dates covered by the current filter, capped at the last date with sales. |
| Subtitle - Executive | `General` | Scope line under the Executive Overview title. |
| Subtitle - Inventory As Of | `General` | Snapshot date line for inventory visuals. |
| Subtitle - Product 360 | `General` | Category, ABC class and sourcing of the product on the drill-through page. |
| Title - Exceptions | `General` | Exception strip: stockouts, late deliveries and late supplier lines. |
| Title - Executive Headline | `General` | Headline sentence for the Executive Overview: Net Sales and like-for-like growth. |
| Title - Inventory Analysis | `General` | Title of the inventory chart driven by its metric and view-by parameters. |
| Title - Logistics Analysis | `General` | Title of the logistics chart driven by its metric and view-by parameters. |
| Title - Procurement Analysis | `General` | Title of the procurement chart driven by its metric and view-by parameters. |
| Title - Product 360 | `General` | Title of the Product 360 drill-through page. |
| Title - Sales Analysis | `General` | Title of the sales chart driven by the Sales Metric and Sales View By parameters. |
| Title - Top N Customers | `General` | Title for a Top N visual: Top N customers by Net Sales. |
| Title - Top N Products | `General` | Title for a Top N visual: Top N products by Net Sales. |
| Title - Top N Suppliers | `General` | Title for a Top N visual: Top N suppliers by PO Value. |
| Title - Top N Warehouses | `General` | Title for a Top N visual: Top N warehouses by Inventory Value. |
| Title - Trend | `General` | Title of the trend chart driven by the Trend Metric and Time Axis parameters. |
| Warehouse Scope Text | `General` | Warehouse selection in words: the name, All warehouses, or a count. |

## Inventory - Counts

| Measure | Format | Meaning |
|---|---|---|
| # Inventory Bins | `#,##0` | Product x warehouse stock positions at the latest snapshot. |

## Inventory - Exceptions

| Measure | Format | Meaning |
|---|---|---|
| # Below Reorder Bins | `#,##0` | Bins below the reorder level at the latest snapshot. |
| # Below Safety Stock Bins | `#,##0` | Bins below the safety stock level at the latest snapshot. |
| # Excess Bins | `#,##0` | Bins with Stock Status Excess at the latest snapshot. |
| # Low Stock Bins | `#,##0` | Bins below safety stock or below the reorder level (the two statuses never overlap), at the latest snapshot. |
| # Stockout Bins | `#,##0` | Bins with Stock Status Stockout at the latest snapshot. Executive Overview exception. |

## Inventory - Quantity

| Measure | Format | Meaning |
|---|---|---|
| Available Quantity | `#,##0` | Units available to promise (on hand minus reserved) at the latest snapshot. |
| In Transit Quantity | `#,##0` | Units on their way into the warehouse at the latest snapshot. |
| On Hand Quantity | `#,##0` | Physical units in stock at the latest snapshot. |
| Reserved Quantity | `#,##0` | Units reserved for customer orders at the latest snapshot. |

## Inventory - Ratios

| Measure | Format | Meaning |
|---|---|---|
| Available Stock (%) | `0.00%` | Available Quantity as a share of On Hand Quantity at the latest snapshot. |
| Average Days Since Last Movement | `#,##0.0` | Average idle time of the bins at the latest snapshot. |
| Dead Stock (%) | `0.00%` | Dead stock value as a share of total inventory value. |
| Excess Inventory (%) | `0.00%` | Excess inventory value as a share of total inventory value. |
| Stock Cover (days) | `#,##0.0` | How many days current on-hand stock lasts at the average daily shipment rate of the 90 days before the snapshot date. Shipments are filtered by the same product and warehouse selection. |
| Stockout Rate (%) | `0.00%` | Stockout bins as a share of all inventory bins. |

## Inventory - Snapshot

| Measure | Format | Meaning |
|---|---|---|
| Latest Snapshot Key *(hidden)* | `0` | Helper: the most recent snapshot date key inside the current filter. Inventory is a stock level, so it is never added up across snapshot dates; every inventory measure reads this snapshot only. |
| Snapshot Date | `dd-MMM-yyyy` | The snapshot date that the inventory measures describe (latest snapshot inside the current date filter). Show it next to inventory cards so users know the as-of date. |

## Inventory - Value

| Measure | Format | Meaning |
|---|---|---|
| Dead Stock Value | `$#,##0.00` | Inventory value of bins with Movement Class Dead Stock, at the latest snapshot. |
| Excess Inventory Value | `$#,##0.00` | Inventory value of bins with Stock Status Excess, at the latest snapshot. |
| Inventory Value | `$#,##0.00` | Stock value (on hand x average unit cost) at the latest snapshot in the filter. Not additive over time. Executive Overview headline KPI. |
| Slow-Moving Value | `$#,##0.00` | Inventory value of bins with Movement Class Slow-Moving, at the latest snapshot. |

## KPI - Comparison

| Measure | Format | Meaning |
|---|---|---|
| Delivery On-Time (%) (ly) | `0.00%` | Delivery On-Time (%) for the same period one year earlier. |
| Delivery On-Time (%) (pp vs ly) | `+0.0%;-0.0%;0.0%` | Change in Delivery On-Time (%) versus the same period last year, in percentage points (0.012 = +1.2 pp). |
| Fill Rate (%) (ly) | `0.00%` | Fill Rate (%) for the same period one year earlier. |
| Fill Rate (%) (pp vs ly) | `+0.0%;-0.0%;0.0%` | Change in Fill Rate (%) versus the same period last year, in percentage points (0.012 = +1.2 pp). |
| Inventory Value (change vs prior) | `$#,##0.00` | Inventory Value minus the prior snapshot's value. |
| Inventory Value (prior snapshot) | `$#,##0.00` | Inventory Value at the snapshot before the latest one in the filter. Blank until a second snapshot exists. |
| Return Rate (%) (ly) | `0.00%` | Return Rate (%) for the same period one year earlier. |
| Return Rate (%) (pp vs ly) | `+0.0%;-0.0%;0.0%` | Change in Return Rate (%) versus the same period last year, in percentage points (0.012 = +1.2 pp). |
| Supplier On-Time (%) (ly) | `0.00%` | Supplier On-Time (%) for the same period one year earlier. |
| Supplier On-Time (%) (pp vs ly) | `+0.0%;-0.0%;0.0%` | Change in Supplier On-Time (%) versus the same period last year, in percentage points (0.012 = +1.2 pp). |

## KPI - Status

| Measure | Format | Meaning |
|---|---|---|
| Delivery On-Time Status | `0` | 1 = on target, 0 = watch (within 2 pp of target), -1 = off target; blank when there is no data. Drives the colour and label. |
| Delivery On-Time Status Color | `General` | Hex colour for Delivery On-Time against its target: green on target, amber watch, red off target. Use as a conditional-format field value. |
| Delivery On-Time Status Label | `General` | Text status for Delivery On-Time: On target / Watch / Off target. |
| Delivery On-Time vs Target | `+0.0%;-0.0%;0.0%` | Delivery On-Time minus its target, in percentage points (0.012 = +1.2 pp). Blank when there is no data. |
| Fill Rate Status | `0` | 1 = on target, 0 = watch (within 2 pp of target), -1 = off target; blank when there is no data. Drives the colour and label. |
| Fill Rate Status Color | `General` | Hex colour for Fill Rate against its target: green on target, amber watch, red off target. Use as a conditional-format field value. |
| Fill Rate Status Label | `General` | Text status for Fill Rate: On target / Watch / Off target. |
| Fill Rate vs Target | `+0.0%;-0.0%;0.0%` | Fill Rate minus its target, in percentage points (0.012 = +1.2 pp). Blank when there is no data. |
| Net Sales Growth Status | `0` | 1 = growing like for like, 0 = down by less than the status tolerance, -1 = declining; based on Net Sales (ytd yoy %). |
| Net Sales Growth Status Color | `General` | Hex colour for Net Sales Growth Status. |
| Net Sales Growth Status Label | `General` | Text status for Net Sales growth: Growing / Flat / Declining. |
| Return Rate Status | `0` | 1 = on target, 0 = watch (within 0.5 pp of target), -1 = off target; blank when there is no data. Drives the colour and label. |
| Return Rate Status Color | `General` | Hex colour for Return Rate against its target: green on target, amber watch, red off target. Use as a conditional-format field value. |
| Return Rate Status Label | `General` | Text status for Return Rate: Within limit / Watch / Over limit. |
| Return Rate vs Target | `+0.0%;-0.0%;0.0%` | Return Rate minus its target, in percentage points (0.012 = +1.2 pp). Blank when there is no data. |
| Stockout Rate Status | `0` | 1 = on target, 0 = watch (within 1 pp of target), -1 = off target; blank when there is no data. Drives the colour and label. |
| Stockout Rate Status Color | `General` | Hex colour for Stockout Rate against its target: green on target, amber watch, red off target. Use as a conditional-format field value. |
| Stockout Rate Status Label | `General` | Text status for Stockout Rate: Within limit / Watch / Over limit. |
| Stockout Rate vs Target | `+0.0%;-0.0%;0.0%` | Stockout Rate minus its target, in percentage points (0.012 = +1.2 pp). Blank when there is no data. |
| Supplier On-Time Status | `0` | 1 = on target, 0 = watch (within 5 pp of target), -1 = off target; blank when there is no data. Drives the colour and label. |
| Supplier On-Time Status Color | `General` | Hex colour for Supplier On-Time against its target: green on target, amber watch, red off target. Use as a conditional-format field value. |
| Supplier On-Time Status Label | `General` | Text status for Supplier On-Time: On target / Watch / Off target. |
| Supplier On-Time vs Target | `+0.0%;-0.0%;0.0%` | Supplier On-Time minus its target, in percentage points (0.012 = +1.2 pp). Blank when there is no data. |

## KPI - Targets

| Measure | Format | Meaning |
|---|---|---|
| Delivery On-Time Target | `0.00%` | Customer delivery on-time goal from the what-if slicer (default 90%). |
| Fill Rate Target | `0.00%` | Fill Rate goal from the Target Fill Rate what-if slicer (default 95%). |
| Return Rate Limit | `0.00%` | Highest acceptable return rate from the what-if slicer (default 2%). Lower is better. |
| Stock Cover Target (days) | `#,##0.0` | Desired days of stock cover from the what-if slicer (default 45). |
| Stockout Rate Limit | `0.00%` | Highest acceptable share of stockout bins from the what-if slicer (default 3%). Lower is better. |
| Supplier On-Time Target | `0.00%` | Supplier on-time goal from the what-if slicer (default 85%). |
| Top N | `0` | Number of items to show in Top N visuals, from the Top N what-if slicer (default 10). |

## Logistics - Counts

| Measure | Format | Meaning |
|---|---|---|
| # On-Time Shipment Lines | `#,##0` | Delivered lines that arrived on or before the promised date. |
| # Shipment Lines | `#,##0` | Number of shipment lines. |
| # Shipments | `#,##0` | Distinct shipments (a shipment can have several lines). |

## Logistics - Date Roles

| Measure | Format | Meaning |
|---|---|---|
| Shipped Quantity (by delivery date) | `#,##0` | Shipped units placed on the date they were actually delivered (uses the inactive Actual Delivery Date relationship). Undelivered lines have no delivery date. |
| Shipped Quantity (by promised date) | `#,##0` | Shipped units placed on the promised delivery date instead of the shipment date (uses the inactive Promised Delivery Date relationship). |

## Logistics - Exceptions

| Measure | Format | Meaning |
|---|---|---|
| # Late Shipment Lines | `#,##0` | Delivered lines that arrived after the promised date. |
| # Pending Deliveries | `#,##0` | Shipment lines not yet delivered, so on-time status is not decided. |
| # Returned Shipment Lines | `#,##0` | Shipment lines flagged as returned by the customer. |

## Logistics - Quantity

| Measure | Format | Meaning |
|---|---|---|
| Customer Received Quantity | `#,##0` | Units recorded as received by the customer. |
| Returned Quantity | `#,##0` | Shipped units on lines flagged as returned. |
| Shipped Quantity | `#,##0` | Units shipped to customers. |

## Logistics - Ratios

| Measure | Format | Meaning |
|---|---|---|
| Average Delivery Delay (days) | `#,##0.0` | Average number of days late, over late lines only (on-time lines have zero or negative delay and are excluded). |
| Delivery On-Time (%) | `0.00%` | On-Time lines divided by On-Time plus Late lines. Pending lines are excluded. Always derived from Delivery Status, never from Shipment Status. Executive Overview headline KPI. |
| Late Delivery Rate (%) | `0.00%` | Late lines divided by On-Time plus Late lines (the complement of Delivery On-Time). |
| Return Rate (%) | `0.00%` | Returned shipment lines as a share of all shipment lines. Executive Overview headline KPI. |

## Logistics - Time Intelligence

| Measure | Format | Meaning |
|---|---|---|
| Shipped Quantity (ly) | `#,##0` | Shipped units for the same period one year earlier. |
| Shipping Cost (ly) | `$#,##0.00` | Shipping Cost for the same period one year earlier. |
| Shipping Cost (yoy %) | `0.00%` | Growth of Shipping Cost versus the same period last year. |
| Shipping Cost (ytd) | `$#,##0.00` | Shipping Cost from 1 January to the last date in the filter. Use on a date axis. |

## Logistics - Value

| Measure | Format | Meaning |
|---|---|---|
| Shipping Cost | `$#,##0.00` | Freight cost of shipments. |
| Shipping Cost per Shipment | `$#,##0.00` | Shipping Cost divided by distinct shipments. |
| Shipping Cost per Unit | `$#,##0.00` | Shipping Cost divided by units shipped. |

## Procurement - Counts

| Measure | Format | Meaning |
|---|---|---|
| # On-Time PO Lines | `#,##0` | Received lines delivered on or before the promised date. |
| # Open PO Lines | `#,##0` | Lines that are Open or Partially Received, so still waiting for goods. |
| # PO Lines | `#,##0` | Number of purchase order lines. |
| # Purchase Orders | `#,##0` | Distinct purchase orders (an order can have several lines). |
| # Suppliers | `#,##0` | Distinct suppliers (by Supplier ID, so supplier history versions are not double counted) that have purchase order lines in the current filter. |

## Procurement - Date Roles

| Measure | Format | Meaning |
|---|---|---|
| Accepted Quantity (by receipt date) | `#,##0` | Accepted units placed on the date the goods were actually received (uses the inactive Actual Receipt Date relationship). Lines not yet received have no receipt date. |
| PO Value (by promised date) | `$#,##0.00` | PO Value placed on the supplier's promised delivery date: what is due when (uses the inactive Promised Delivery Date relationship). |
| PO Value (by requested date) | `$#,##0.00` | PO Value placed on the requested delivery date instead of the order date (uses the inactive Requested Delivery Date relationship). |

## Procurement - Exceptions

| Measure | Format | Meaning |
|---|---|---|
| # Late PO Lines | `#,##0` | Received lines delivered after the promised date. |
| # Pending PO Lines | `#,##0` | Lines with no receipt yet, so on-time status is not decided. |

## Procurement - Quantity

| Measure | Format | Meaning |
|---|---|---|
| Accepted Quantity | `#,##0` | Units accepted at goods receipt inspection. |
| Open Quantity | `#,##0` | Units ordered but not yet received. |
| Ordered Quantity | `#,##0` | Units ordered from suppliers. |
| Received Quantity | `#,##0` | Accepted-to-date units received against the purchase order lines. |
| Rejected Quantity | `#,##0` | Units rejected at goods receipt inspection. |

## Procurement - Ratios

| Measure | Format | Meaning |
|---|---|---|
| Average Supplier Delay (days) | `#,##0.0` | Average number of days late, over late lines only (on-time lines have zero or negative delay and are excluded). |
| Late PO Value (%) | `0.00%` | Late PO Value as a share of PO Value. |
| Open PO Value (%) | `0.00%` | Open PO Value as a share of PO Value. |
| Receipt Completion (%) | `0.00%` | Received Quantity as a share of Ordered Quantity. Cancelled lines stay in Ordered Quantity, so exclude them with a filter if needed. |
| Rejection Rate (%) | `0.00%` | Rejected units as a share of all physically received units (Accepted plus Rejected). |
| Supplier On-Time (%) | `0.00%` | On-Time lines divided by On-Time plus Late lines. Pending lines are excluded. Always derived from Delivery Status, never from PO Status. Executive Overview headline KPI. |

## Procurement - Time Intelligence

| Measure | Format | Meaning |
|---|---|---|
| PO Value (ly) | `$#,##0.00` | PO Value for the same period one year earlier. |
| PO Value (yoy %) | `0.00%` | Growth of PO Value versus the same period last year. |
| PO Value (ytd) | `$#,##0.00` | PO Value from 1 January to the last date in the filter. Use on a date axis. |

## Procurement - Value

| Measure | Format | Meaning |
|---|---|---|
| Late PO Value | `$#,##0.00` | Value of purchase order lines delivered late. |
| Open PO Value | `$#,##0.00` | Value of quantity still to be received: Open Quantity x Unit Cost, evaluated line by line. |
| PO Value | `$#,##0.00` | Ordered value across all purchase order lines (Line Amount). |
| Rejected Value | `$#,##0.00` | Cost of goods rejected at inspection: Rejected Quantity x Unit Cost, line by line. |

## Reference Lines

| Measure | Format | Meaning |
|---|---|---|
| Net Sales Average Line | `$#,##0.00` | Average monthly Net Sales across the months in the visual. |
| Trend Metric Average Line | `General` | Average of the monthly values of the metric selected in Trend Metric. Use as a dynamic reference line. |
| Trend Metric Target Line | `General` | Target of the metric selected in Trend Metric; blank where the metric has no target. Use as a dynamic reference line. |

## Sales - Counts

| Measure | Format | Meaning |
|---|---|---|
| # Ordering Customers | `#,##0` | Distinct customers with at least one order line in the current filter. |
| # Products Sold | `#,##0` | Distinct products with at least one order line in the current filter. |
| # Sales Order Lines | `#,##0` | Number of order lines. |
| # Sales Orders | `#,##0` | Distinct sales orders (an order can have several lines). |

## Sales - Date Roles

| Measure | Format | Meaning |
|---|---|---|
| Net Sales (by promised date) | `$#,##0.00` | Net Sales placed on the promised delivery date instead of the order date (uses the inactive Promised Delivery Date relationship). |
| Net Sales (by requested date) | `$#,##0.00` | Net Sales placed on the customer's requested delivery date instead of the order date (uses the inactive Requested Delivery Date relationship). |

## Sales - Exceptions

| Measure | Format | Meaning |
|---|---|---|
| # Backordered Lines | `#,##0` | Order lines whose status is Backordered. |
| # Cancelled Lines | `#,##0` | Order lines whose status is Cancelled. |

## Sales - Quantity

| Measure | Format | Meaning |
|---|---|---|
| Backorder Quantity | `#,##0` | Units ordered but not fulfilled because stock was insufficient. |
| Fulfilled Quantity | `#,##0` | Units that could be fulfilled from stock. |
| Order Quantity | `#,##0` | Units ordered by customers. |

## Sales - Ratios

| Measure | Format | Meaning |
|---|---|---|
| Backorder Rate (%) | `0.00%` | Backorder Quantity as a share of Order Quantity. |
| Discount (%) | `0.00%` | Discount Amount as a share of Gross Sales. |
| Fill Rate (%) | `0.00%` | Fulfilled Quantity as a share of Order Quantity. Calculated from totals, so it is correct at any level (never average the row-level ratio). Executive Overview headline KPI. |

## Sales - Time Intelligence

| Measure | Format | Meaning |
|---|---|---|
| Net Sales (3m avg) | `$#,##0.00` | Average monthly Net Sales over the 3 months ending at the last date in the filter. Smooths a monthly trend. |
| Net Sales (change vs ly) | `$#,##0.00` | Net Sales minus the same period last year. |
| Net Sales (ltm) | `$#,##0.00` | Net Sales over the 12 months ending at the last date in the filter. Use on a date axis. |
| Net Sales (ly) | `$#,##0.00` | Net Sales for the same period one year earlier. |
| Net Sales (mtd) | `$#,##0.00` | Net Sales from the start of the month to the last date in the filter. Use on a date axis; for cards use the Period Selector measures. |
| Net Sales (qtd) | `$#,##0.00` | Net Sales from the start of the quarter to the last date in the filter. Use on a date axis. |
| Net Sales (yoy %) | `0.00%` | Growth of Net Sales versus the same period last year. For a partial year (data ends in August) use Net Sales (ytd yoy %) instead, which compares like for like. |
| Net Sales (ytd ly) | `$#,##0.00` | Year-to-date Net Sales for the same period one year earlier. |
| Net Sales (ytd yoy %) | `0.00%` | Like-for-like growth: year-to-date Net Sales up to the cut-off date versus the same days one year earlier. The cut-off is the earlier of the last date in the filter and the last date with sales, so a partial current year is compared fairly. Executive Overview headline KPI. |
| Net Sales (ytd) | `$#,##0.00` | Net Sales from 1 January up to the last date in the current filter. |

## Sales - Value

| Measure | Format | Meaning |
|---|---|---|
| Average Order Value | `$#,##0.00` | Net Sales per distinct sales order. Order lines of one order are not counted separately. |
| Discount Amount | `$#,##0.00` | Total discount granted (Gross Sales minus Net Sales). |
| Gross Sales | `$#,##0.00` | Order value before discounts (Gross Line Amount). |
| Net Sales | `$#,##0.00` | Order value after discounts (Net Line Amount) across all order lines, including cancelled ones. Reconciles to the validated Net Sales golden total. Executive Overview headline KPI. |

## Scenario

| Measure | Format | Meaning |
|---|---|---|
| Net Sales (scenario change) | `$#,##0.00` | Scenario Net Sales minus actual Net Sales. |
| Net Sales (scenario) | `$#,##0.00` | Net Sales if prices and volumes moved by the scenario percentages. A simple what-if: it does not model price elasticity. |
| Price Change (scenario) | `0.00%` | Assumed price change for the Net Sales scenario, from the what-if slicer (default 0%). |
| Shipping Cost (scenario) | `$#,##0.00` | Shipping Cost if volumes moved by the scenario percentage (freight assumed proportional to volume). |
| Volume Change (scenario) | `0.00%` | Assumed volume change for the scenario measures, from the what-if slicer (default 0%). |

## Share and Rank

| Measure | Format | Meaning |
|---|---|---|
| Carrier Rank (Shipping Cost) | `0` | Rank of the carrier by Shipping Cost among the carriers in the visual (1 = highest). Blank unless the carrier name is on the visual. |
| Customer Rank (Net Sales) | `0` | Rank of the customer by Net Sales among the customers in the visual (1 = highest). Blank unless the customer name is on the visual. |
| Inventory Value (% of total) | `0.00%` | Share of Inventory Value across the items shown in the visual. |
| Is Top N Carrier (Shipping Cost) | `0` | 1 when the item is within the Top N carriers (N from the Top N slicer). Use as a visual-level filter (= 1); the Top N visual filter cannot read a slicer. |
| Is Top N Customer (Net Sales) | `0` | 1 when the item is within the Top N customers (N from the Top N slicer). Use as a visual-level filter (= 1); the Top N visual filter cannot read a slicer. |
| Is Top N Product (Net Sales) | `0` | 1 when the item is within the Top N products (N from the Top N slicer). Use as a visual-level filter (= 1); the Top N visual filter cannot read a slicer. |
| Is Top N Supplier (PO Value) | `0` | 1 when the item is within the Top N suppliers (N from the Top N slicer). Use as a visual-level filter (= 1); the Top N visual filter cannot read a slicer. |
| Is Top N Warehouse (Inventory Value) | `0` | 1 when the item is within the Top N warehouses (N from the Top N slicer). Use as a visual-level filter (= 1); the Top N visual filter cannot read a slicer. |
| Net Sales (% of total) | `0.00%` | Share of Net Sales across the items shown in the visual (slicers respected). |
| PO Value (% of total) | `0.00%` | Share of PO Value across the items shown in the visual. |
| Product Rank (Net Sales) | `0` | Rank of the product by Net Sales among the products in the visual (1 = highest). Blank unless the product name is on the visual. |
| Shipped Quantity (% of total) | `0.00%` | Share of shipped units across the items shown in the visual. |
| Shipping Cost (% of total) | `0.00%` | Share of Shipping Cost across the items shown in the visual. |
| Supplier Rank (PO Value) | `0` | Rank of the supplier by PO Value among the suppliers in the visual (1 = highest). Blank unless the supplier name is on the visual. |
| Warehouse Rank (Inventory Value) | `0` | Rank of the warehouse by Inventory Value among the warehouses in the visual (1 = highest). Blank unless the warehouse name is on the visual. |

## Tooltips

| Measure | Format | Meaning |
|---|---|---|
| Tooltip - Delivery | `General` | Tooltip line: delivery on-time and late lines. |
| Tooltip - Fulfillment | `General` | Tooltip line: fill rate and backorder units. |
| Tooltip - Inventory | `General` | Tooltip line: inventory value and stock cover. |
| Tooltip - Net Sales | `General` | Tooltip line: Net Sales and its share of the total. |
| Tooltip - Net Sales vs LY | `General` | Tooltip line: growth versus last year. |
| Tooltip - Product Rank | `General` | Tooltip line: product rank by Net Sales. |
| Tooltip - Supplier | `General` | Tooltip line: supplier on-time and rejection rate. |
