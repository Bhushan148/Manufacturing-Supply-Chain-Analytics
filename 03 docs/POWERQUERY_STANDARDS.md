# Power Query Standards — Manufacturing Supply Chain Model

Rules for the shared semantic model so transformations **fold** back to SQL Server
(`Manufacturing_DW`) and refresh/incremental refresh stay efficient.
All shaping is done in Power Query **before** modelling (relationships, measures, RLS).

## Connect
- Server and database come from the parameters **`ServerName`** (`localhost`) and **`DatabaseName`** (`Manufacturing_DW`). Repoint them in one place for the gateway; never hard-code them in a query.
- Pick the **`bi.*` views**. **Do not** paste a SQL query — navigation (`Source{[Schema="bi", Item="..."]}`) preserves folding.
- One query per `bi` view (10 total). **Table names keep the `Dim` / `Fact` prefix** (project decision, matches the SQL objects): DimDate, DimProduct, DimSupplier, DimCustomer, DimWarehouse, DimCarrier, FactSalesOrder, FactPurchaseOrder, FactShipment, FactInventorySnapshot.

## Query step conventions
- Step names are `#"..."`, start with a past-tense verb, use spaces, max 50 chars (`#"Removed derived ratio column"`).
- A `//` comment above each step says what it does (max 225 chars, no step numbers, no code).
- Order: connect → navigate → **filter rows (refresh window)** → remove columns → change types → add columns.

## Transformations applied (all foldable)
| Table | Steps |
|---|---|
| All Fact tables | Incremental refresh window filter on the date key (see below). Money columns → `Currency.Type` (fixed decimal; avoids double rounding). |
| FactSalesOrder | Removes `Fill Rate Percent` (row-level ratio; use a DAX measure). |
| FactInventorySnapshot | `Last Movement DateTime` → `Last Movement Date` (date only; lower cardinality). |
| DimSupplier | `Effective Start` / `Effective End` → date. |
| DimDate | Adds `Year Month Number` (sort key for `Year-Month`). |
| DimProduct | `Standard Cost`, `List Price` → fixed decimal. |

## Incremental refresh
- Parameters `RangeStart` / `RangeEnd` (DateTime, defaults 2020-01-01 / 2027-12-31 so Desktop loads everything) and function `fnDateTimeToDateKey` (datetime → `yyyymmdd` integer).
- The facts only carry integer date keys, so the filter is `[Key] >= fnDateTimeToDateKey(RangeStart) and [Key] < fnDateTimeToDateKey(RangeEnd)`.
- Policy (`refreshPolicy` in each table, applies on publish): rolling window **6 years**; refresh the last
  **6 months** (FactSalesOrder, FactPurchaseOrder on `OrderDateKey`) or **3 months** (FactShipment on `ShipmentDateKey`,
  FactInventorySnapshot on `SnapshotDateKey`).
- Late-arriving changes older than the refresh window (e.g. a PO receipt 8 months after order) are not picked up — widen `incrementalPeriods` if that matters.
- **Verify folding** on the filter step (View Native Query) after opening in Desktop.

## Keep every step foldable
Safe: filter rows, remove/select/rename columns, change type, `DateTime.Date`, simple arithmetic columns, sort, Group By, Merge/Append.
Avoid: **Index** column, `Table.Buffer`, complex custom-M, row-by-row logic, native SQL.

## Verify folding
Right-click the **last** applied step ▸ **View Native Query**.
- Enabled → that query folds ✅
- Greyed out → folding broke at that step → move/replace it, or push the logic into a
  SQL view (`sql\05_bi_views.sql` style) and select from that instead.

## Model hygiene (already applied in the TMDL)
- Auto date/time **off**; `LocalDateTable_*` tables removed.
- `DimDate` marked as the date table; `Month Name` / `Day Name` / `Year-Month` sorted chronologically.
- All `*Key` columns and fact line IDs hidden; non-additive numerics have no default summarization.
- Relationships: single-direction Dim → Fact; one active date relationship per fact, the rest inactive for `USERELATIONSHIP`. No fact-to-fact relationships.
- Not yet done (modelling stage): measures (then hide the base columns and enable `discourageImplicitMeasures`), hierarchies, RLS.
