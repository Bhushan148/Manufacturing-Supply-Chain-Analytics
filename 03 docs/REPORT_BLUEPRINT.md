# Report Blueprint — three thin reports

Plan for building the reports once the model loads cleanly. **Nothing here is built yet.** The model side (measures, parameters, selectors, sort columns, security) is done; this file says what each page needs from it and which report-time features are still to do. Measure names are in [MEASURES.md](MEASURES.md).

Design follows the `powerbi-authoring:powerbi-report-cli` design references (archetypes, interactivity budget, slicer placement, bookmark rules).

## Plan changes made after checking the design references
| Earlier plan | Change | Why |
|---|---|---|
| Report 2 = one dense page with inventory and procurement | One page with a **view switch** (Inventory / Procurement) built from two bookmarks, plus the Product 360 drill-through page | Keeps each view readable; a dense two-topic page breaks the "primary insight visible on load" rule |
| Page navigator inside every report | **No page navigator.** The App is the navigation between the three reports; inside a report use bookmarks and drill-through only | Rule: one primary navigation model; the App already provides it. Each report has 1–2 pages |
| Slicers anywhere | Filter strip across the top (period, warehouse, customer type); nothing in the top-left focal area | Slicer placement rule |
| Personalize visuals on everywhere | Only on Report 2 (analytical); off on Executive | Executives get 1–2 clicks |
| Static chart titles | Dynamic titles from `Dynamic - Titles` | "Headlines as answers" |

## Report 1 — Executive Overview
Archetype: **executive summary**. Interaction budget: minimal (0–1 clicks to insight).
- **Row 1, headline:** `Title - Executive Headline`, `Subtitle - Executive`.
- **Row 2, six KPI cards:** Net Sales (+ `Net Sales (ytd yoy %)`), Fill Rate, Delivery On-Time, Supplier On-Time, Return Rate, Inventory Value (+ `Subtitle - Inventory As Of`). Each card: value, variance (`... vs Target` / `(pp vs ly)`), colour from `... Status Color`, label from `... Status Label`.
- **Dynamic KPI card (optional hero):** `Selected KPI Value Text`, `Selected KPI Variance Text`, `Selected KPI Status Color`, with slicers KPI Selector, Period Selector, Compare To.
- **Trend:** line chart, field parameters `Trend Metric` (value) and `Time Axis` (axis), reference lines `Trend Metric Target Line` and `Trend Metric Average Line`, title `Title - Trend`.
- **Exceptions strip:** `Title - Exceptions`, plus a small table of worst warehouses by `# Stockout Bins` and worst carriers by `Late Delivery Rate (%)`.
- **Tooltip page:** trend tooltip with `Tooltip - Net Sales`, `Tooltip - Net Sales vs LY`.

## Report 2 — Inventory & Procurement
Archetype: **operational monitor** with an analytical drill-through. Interaction budget: moderate.
- **View switch:** two bookmarks (Inventory view, Procurement view) toggling visibility groups through buttons; plus a Reset bookmark.
- **Inventory view:** KPI row (Inventory Value, # Stockout Bins, Stockout Rate, Dead Stock (%), Stock Cover (days)); chart driven by `Inventory Metric` x `Inventory View By`; bar of Top N warehouses (`Is Top N Warehouse (Inventory Value)` = 1); matrix with rows from `Inventory View By`, columns `Stock Status` (sorted by `Stock Status Sort`). Title `Title - Inventory Analysis`.
- **Procurement view:** KPI row (PO Value, Open PO Value, Supplier On-Time, Rejection Rate, Average Supplier Delay); chart driven by `Procurement Metric` x `Procurement View By`; supplier risk breakdown (sorted by `Supplier Risk Sort`); Top N suppliers.
- **Product 360 drill-through** (field `DimProduct[Product Name]`): `Title - Product 360`, `Subtitle - Product 360`, Net Sales, `Product Share of Net Sales (%)`, `Fill Rate vs All Products (pp)`, `# Warehouses Stocking`, Stock Cover (days), `# Suppliers`; back button.
- **Tooltip page:** product tooltip with `Tooltip - Product Rank`, `Tooltip - Inventory`, `Tooltip - Supplier`.
- **What-if slicers:** Target Stock Cover, Limit Stockout Rate, Top N.

## Report 3 — Fulfillment & Logistics
Archetype: **operational monitor / comparative benchmark** (fulfillment on the left, logistics on the right).
- **KPI rows:** Fulfillment — Net Sales, Fill Rate, Backorder Quantity, Average Order Value. Logistics — Delivery On-Time, Average Delivery Delay, Shipping Cost per Unit, Return Rate.
- **Charts:** `Sales Metric` x `Sales View By` (by customer type, channel, category…); `Logistics Metric` x `Logistics View By` (carrier, mode, service level, destination region); Top N customers and Top N carriers.
- **Scenario panel:** `Net Sales (scenario)` with the Price and Volume change slicers.
- **Date roles:** small chart switching Net Sales and Shipped Quantity between order, requested, promised and delivery dates using the `(by ... date)` measures.
- **Tooltip page:** `Tooltip - Fulfillment`, `Tooltip - Delivery`.

## Where each requested topic is handled
"Model" = object already exists. "Report" = to do when building the reports.

| Topic | Where |
|---|---|
| Field parameters, for rows/columns, dynamic axis, dynamic legend | **Model:** `Trend Metric`, `Sales/Procurement/Logistics/Inventory Metric`, `... View By`, `Time Axis`. Report: bind slicers, put the `View By` field in rows, legend or axis |
| Disconnected tables | **Model:** `KPI Selector`, `Period Selector`, `Comparison Selector`, `Time Basis` |
| SWITCH measures, dynamic measure selection | **Model:** the KPI engine (`Selected KPI ...`), `Net Sales (time basis)` |
| Dynamic titles and subtitles | **Model:** `Dynamic - Titles`. Report: bind through the title's *fx* |
| Dynamic KPI cards | **Model:** `Dynamic - KPI Selection`. Report: card + three slicers |
| Conditional formatting, icons | **Model:** `... Status Color` / `Status Label` measures and the hidden palette. Report: format by field value. Data bars: report-level only |
| Report page tooltips | **Model:** `Tooltips`. Report: tooltip pages |
| Drillthrough | **Model:** `Drillthrough`. Report: Product 360 page, back button |
| Top N filters | **Model:** `Top N` what-if and `Is Top N ...` flags (filter = 1). Report: apply the visual-level filter |
| What-if parameters | **Model:** the 9 `Target ...`, `Limit ...`, `Scenario ...`, `Top N Selector` tables |
| Relative date filters | **Model:** `Period Selector` + `Is In Selected Period` (anchored to the last sales date, because the data ends in August 2026 and "last 3 months from today" would be empty). Report: either this, or the native relative-date filter on a date field |
| Reference lines | **Model:** `Reference Lines`, plus the target measures. Report: add as dynamic lines |
| Sort by column, custom sort order | **Model:** hidden `... Sort` columns (stock status, delivery status, priority, risk, tier, segment, rating, year quarter) set as sort-by |
| Measure branching | **Model:** KPI engine, status, titles and tooltips all build on base measures |
| Matrix hierarchies, expand/collapse | **Model:** Calendar, Product, and geography hierarchies. Report: matrix with expand/collapse |
| Small multiples, sparklines | **Report:** use existing measures; no extra model object |
| Visual calculations | **Report:** running sum and moving average inside the visual (they cannot be reused across visuals) |
| Bookmarks, buttons, selection pane, show/hide, dynamic visibility, conditional navigation | **Report:** bookmark pairs (view switch), reset button. Visibility cannot be driven by a measure; use bookmarks |
| Page navigation, bookmark navigation | **Report:** bookmark navigator for the view switch only; no page navigator (see plan changes) |
| Sync slicers, edit interactions, slicer panels, reset filters button | **Report:** sync period and warehouse slicers by field; set cards to Filter and reference visuals to None |
| Visual-level, page-level, report-level filters | **Report:** report-level none; page-level for anything fixed; visual-level for Top N flags |
| Personalize visuals | **Report:** Report 2 only |
| Mobile layout, accessibility, themes, custom themes, grid/snap, grouping, lock objects, Performance Analyzer | **Report:** one custom theme (the palette is also in the hidden colour measures), alt text and tab order per page, mobile layout for Report 1 and 3 KPI rows, group each section and lock backgrounds, run Performance Analyzer before publishing |

## Check before building
1. Open the model in Desktop, refresh, and run `validation\golden_totals.dax` and `validation\dynamic_tests.dax`.
2. View as role `Warehouse Manager` (see [RLS.md](RLS.md)) and re-check the date-role measures.
3. Decide the two open story questions from `sql\FINDINGS.md`: supplier on-time (42.9%) and dead stock (~78%); the status colours will show red for both until the data or the targets change.
